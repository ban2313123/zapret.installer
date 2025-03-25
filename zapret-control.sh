#!/bin/bash

set -e  

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi


detect_init() {
    if [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v openrc-init >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    elif command -v runit >/dev/null 2>&1; then
        INIT_SYSTEM="runit"
    elif [ -x /sbin/init ] && /sbin/init --version 2>&1 | grep -q "sysvinit"; then
        INIT_SYSTEM="sysvinit"
    else
        INIT_SYSTEM="unknown"
        echo "Ваш Init не поддерживается."
        exit 0
    fi
}

check_zapret_exist() {

    case "$INIT_SYSTEM" in
        systemd)
            if [ -f /etc/systemd/system/timers.target.wants/zapret-list-update.timer ]; then
                service_exists=true
            else
                service_exists=false
            fi
            ;;
        openrc)
            rc-service -l | grep -q "zapret" && service_exists=true || service_exists=false
            ;;
        runit)
            [ -d /etc/service/zapret ] && service_exists=true || service_exists=false
            ;;
        sysvinit)
            [ -f /etc/init.d/zapret ] && service_exists=true || service_exists=false
            ;;
        *)
            ZAPRET_EXIST=false
            return
            ;;
    esac


    if [ -d /opt/zapret ]; then
        dir_exists=true
        [ -d /opt/zapret/binaries ] && binaries_exists=true || binaries_exists=false
    else
        dir_exists=false
        binaries_exists=false
    fi


    if [ "$service_exists" = true ] && [ "$dir_exists" = true ] && [ "$binaries_exists" = true ]; then
        ZAPRET_EXIST=true
    else
        ZAPRET_EXIST=false
    fi
}


check_zapret_status() {
    case "$INIT_SYSTEM" in
        systemd)
        ZAPRET_ACTIVE=$(systemctl show -p ActiveState zapret | cut -d= -f2 || true)
        ZAPRET_ENABLED=$(systemctl is-enabled zapret 2>/dev/null || echo "false")
        ZAPRET_SUBSTATE=$(systemctl show -p SubState zapret | cut -d= -f2)
        if [[ "$ZAPRET_ACTIVE" == "active" && "$ZAPRET_SUBSTATE" == "running" ]]; then
           ZAPRET_ACTIVE=true
        else
            ZAPRET_ACTIVE=false
        fi
        
        if [[ "$ZAPRET_ENABLED" == "enabled" ]]; then
            ZAPRET_ENABLED=true
        else
            ZAPRET_ENABLED=false
        fi
        if [[ "$ZAPRET_ENABLED" == "not-found" ]]; then
            ZAPRET_ENABLED=false
        fi
        ;;
        openrc)
            rc-service zapret status >/dev/null 2>&1 && ZAPRET_ACTIVE=true || ZAPRET_ACTIVE=false
            rc-update show | grep -q zapret && ZAPRET_ENABLED=true || ZAPRET_ENABLED=false
            ;;
        runit)
            sv status zapret >/dev/null 2>&1 && ZAPRET_ACTIVE=true || ZAPRET_ACTIVE=false
            [ -L /var/service/zapret ] && ZAPRET_ENABLED=true || ZAPRET_ENABLED=false
            ;;
        sysvinit)
            service zapret status >/dev/null 2>&1 && ZAPRET_ACTIVE=true || ZAPRET_ACTIVE=false
            ;;
    esac
}


exists() {
    command -v "$1" >/dev/null 2>&1
}

get_fwtype() {
    [ -n "$FWTYPE" ] && return

    local UNAME="$(uname)"

    case "$UNAME" in
        Linux)

            if exists iptables; then
                iptables_version=$(iptables -V 2>&1)

                if [[ "$iptables_version" == *"legacy"* ]]; then
                    FWTYPE="iptables"
                elif [[ "$iptables_version" == *"nf_tables"* ]]; then
                    FWTYPE="nftables"
                else
                    echo "Не удалось определить файрвол. По умолчанию установлен iptables, вы его можете изменить в файле /opt/zapret/config."
                    echo "Продолжаю через 5 секунд..."
                    FWTYPE="iptables"
                    sleep 5
                fi
            else
                echo "Не удалось определить файрвол. По умолчанию установлен iptables, вы его можете изменить в файле /opt/zapret/config."
                echo "Продолжаю через 5 секунд..."
                
                FWTYPE="iptables"
                sleep 5
            fi
            ;;
        FreeBSD)
            if exists ipfw ; then
                FWTYPE="ipfw"
            else
                echo "Не удалось определить файрвол. По умолчанию установлен iptables, вы его можете изменить в файле /opt/zapret/config."
                echo "Продолжаю через 5 секунд..."
                
                FWTYPE="iptables"
                sleep 5
            fi
            ;;
        *)
        echo "Не удалось определить файрвол. По умолчанию установлен iptables, вы его можете изменить в файле /opt/zapret/config."
        echo "Продолжаю через 5 секунд..."
        
        FWTYPE="iptables"
        sleep 5
            ;;
    esac

}


manage_service() {
    case "$INIT_SYSTEM" in
        systemd)
            SYSTEMD_PAGER=cat systemctl "$1" zapret
            ;;
        openrc)
            rc-service zapret "$1"
            ;;
        runit)
            sv "$1" zapret
            ;;
        sysvinit)
            service zapret "$1"
            ;;
    esac
}

manage_autostart() {
    case "$INIT_SYSTEM" in
        systemd)
            systemctl "$1" zapret
            ;;
        openrc)
            if [[ "$1" == "enable" ]]; then
                rc-update add zapret default
            else
                rc-update del zapret default
            fi
            ;;
        runit)
            if [[ "$1" == "enable" ]]; then
                ln -s /etc/sv/zapret /var/service/
            else
                rm -f /var/service/zapret
            fi
            ;;
        sysvinit)
            if [[ "$1" == "enable" ]]; then
                update-rc.d zapret defaults
            else
                update-rc.d -f zapret remove
            fi
            ;;
    esac
}

install_dependencies() {
    kernel="$(uname -s)"
    if [ "$kernel" = "Linux" ]; then
        . /etc/os-release

        declare -A command_by_ID=(
            ["arch"]="pacman -S --noconfirm make gcc wget libcap ipset \
                            libnetfilter_queue"
            ["debian"]="DEBIAN_FRONTEND=noninteractive apt install -y make gcc zlib1g-dev ipset iptables \
                            libcap-dev wget libnetfilter-queue-dev"
            ["fedora"]="dnf install -y make gcc zlib-devel ipset iptables \
                            libcap-devel wget libnetfilter_queue-devel"
            ["ubuntu"]="DEBIAN_FRONTEND=noninteractive apt install -y make gcc zlib1g-dev wget ipset iptables \
                            libcap-dev libnetfilter-queue-dev"
            ["mint"]="DEBIAN_FRONTEND=noninteractive apt install -y make gcc wget zlib1g-dev ipset iptables \
                            libcap-dev git libnetfilter-queue-dev"
            ["void"]="xpbs-install -y make gcc git zlib libcap wget ipset iptables \
                            libnetfilter_queue"
            ["gentoo"]="emerge --ask=n sys-libs/zlib dev-vcs/git net-firewall/iptables net-misc/wget net-firewall/ipset sys-libs/libcap  \
                            net-libs/libnetfilter_queue"
            ["opensuse"]="zypper install -y make git gcc wget zlib-devel ipset iptables \
                            libcap-devel libnetfilter_queue-devel"
        )

        if [[ -v command_by_ID[$ID] ]]; then
            eval "${command_by_ID[$ID]}"
        elif [[ -v command_by_ID[$ID_LIKE] ]]; then
            eval "${command_by_ID[$ID_LIKE]}"
        fi
    elif [ "$kernel" = "Darwin" ]; then
        echo "macOS не поддерживается на данный момент." 
        exit 1
    else
        echo "Неизвестная ОС: ${kernel}"
        exit 1
    fi
}



main_menu() {
    while true; do
        clear
        check_zapret_status
        check_zapret_exist
        echo "===== Меню управления Запретом ====="
        if [[ $ZAPRET_ACTIVE == true ]]; then echo "!Запрет запущен!"; fi
        if [[ $ZAPRET_ACTIVE == false ]]; then echo "!Запрет выключен!"; fi 
        if [[ $ZAPRET_EXIST == false ]]; then clear; echo "===== Меню управления Запретом ====="; echo "!Запрет не установлен!"; fi
        if [[ $ZAPRET_EXIST == true ]]; then
            echo "1) Проверить на обновления и обновить"
            echo "2) Сменить конфигурацию запрета"
            echo "3) Перезапустить Запрет"
            echo "4) Посмотреть статус Запрета"
            if [[ $ZAPRET_ENABLED == false ]]; then echo "5) Добавить в автозагрузку"; fi
            if [[ $ZAPRET_ACTIVE == false ]]; then echo "6) Включить Запрет"; fi
            if [[ $ZAPRET_ENABLED == true ]]; then echo "7) Убрать из автозагрузки"; fi
            if [[ $ZAPRET_ACTIVE == true ]]; then echo "8) Выключить Запрет"; fi
            echo "9) Удалить Запрет"
            echo "10) Выйти"
            read -p "Выберите действие: " CHOICE
            case "$CHOICE" in
                1) update_zapret;;
                2) change_configuration;;
                3) manage_service restart;;
                4) manage_service status; bash -c 'read -p "Нажмите Enter для продолжения..."';;
                5) manage_autostart enable;;
                6) manage_service start;;
                7) manage_autostart disable;;
                8) manage_service stop;;
                9) uninstall_zapret;;
                10) exit 0;;
                *) echo "Неверный ввод!"; sleep 2;;
            esac
        else
            echo "1) Установить Запрет"
            echo "2) Проверить скрипт на обновления"
            echo "3) Выйти"
            read -p "Выберите действие: " CHOICE
            case "$CHOICE" in
                1) install_zapret; main_menu;;
                2) update_script;;
                3) exit 0;;
                *) echo "Неверный ввод!"; sleep 2;;
            esac
        fi
    done
}


install_zapret() {
    install_dependencies
    if [[ $dir_exists == true ]]; then
        read -p "На вашем компьютере был найден запрет (/opt/zapret). Для продолжения его необходимо удалить. Вы дествительно хотите удалить запрет (/opt/zapret) и продолжить? (y/N): " answer
        case "$answer" in
            [Yy]* ) 
                if [[ -f /opt/zapret/uninstall_easy.sh ]]; then
                    cd /opt/zapret
                    yes "" | ./uninstall_easy.sh
                fi
                rm -rf /opt/zapret

                ;;
            * ) 
                main_menu
                ;;
        esac
    fi
    

    echo "Клонирую репозиторий..."
    if ! git clone https://github.com/bol-van/zapret /opt/zapret ; then
         echo "Ошибка: нестабильноe/слабое подключение к интернету."
    exit 1
    fi
    echo "Клонирование успешно завершено."

    echo "Клонирую репозиторий..."
        if ! git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs ; then
    echo "Ошибка: нестабильноe/слабое подключение к интернету."
    exit 1
    fi
    echo "Клонирование успешно завершено."
    

    if [[ ! -d /opt/zapret.installer/zapret.binaries ]]; then
        echo "Клонирую релиз запрета..."
        mkdir -p /opt/zapret.installer/zapret.binaries
        if ! wget -P /opt/zapret.installer/zapret.binaries/zapret https://github.com/bol-van/zapret/releases/download/v70.4/zapret-v70.4.tar.gz; then
            echo "Ошибка: не удалось получить релиз запрета."
            exit 1
        fi
        echo "Получение запрета завершено."
        tar -xzf /opt/zapret.installer/zapret.binaries/zapret/zapret-v70.4.tar.gz -C /opt/zapret.installer/zapret.binaries/zapret
        cp -r /opt/zapret.installer/zapret.binaries/zapret/zapret-v70.4/binaries/ /opt/zapret/binaries

    fi
    if [[ ! -d /opt/zapret/binaries ]]; then
        tar -xzf /opt/zapret.installer/zapret.binaries/zapret/zapret-v70.4.tar.gz -C /opt/zapret.installer/zapret.binaries/zapret
        cp -r /opt/zapret.installer/zapret.binaries/zapret/zapret-v70.4/binaries/ /opt/zapret/binaries
    fi
     
    cp /opt/zapret/zapret.cfgs/binaries/* /opt/zapret/files/fake/

    cd /opt/zapret
    yes "" | ./install_easy.sh
    cp -r /opt/zapret.installer/zapret-control.sh /bin/zapret || exit 
    chmod +x /bin/zapret
    rm -f /opt/zapret/config 
    cp -r /opt/zapret/zapret.cfgs/configurations/general /opt/zapret/config || exit
    rm -f /opt/zapret/ipset/zapret-hosts-user.txt
    cp -r /opt/zapret/zapret.cfgs/lists/list-basic.txt /opt/zapret/ipset/zapret-hosts-user.txt || exit
    manage_service restart
    configure_zapret_conf
    
}

change_configuration(){
    while true; do
        clear
        echo "===== Меню управления Запретом ====="
        echo "1) Сменить стратегию"
        echo "2) Сменить лист обхода"
        echo "3) Добавить ip-адреса или домены в лист обхода"
        echo "4) Удалить ip-адреса или домены из листа обхода"
        echo "5) Выйти в меню"
        read -p "Выберите действие: " CHOICE
        case "$CHOICE" in
            1) configure_zapret_conf;;
            2) configure_zapret_list;;
            3) add_to_zapret;;
            4) delete_from_zapret;;
            5) main_menu;;
            *) echo "Неверный ввод!"; sleep 2;;
        esac
    done
}

update_zapret() {
    if [[ -d /opt/zapret ]]; then
        cd /opt/zapret && git pull
    fi
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        cd /opt/zapret/zapret.cfgs && git pull
    fi
    if [[ -d /opt/zapret.installer/ ]]; then
        cd /opt/zapret.installer/ && git pull
        rm -f /bin/zapret
        cp -r /opt/zapret.installer/zapret-control.sh /bin/zapret || exit
        chmod +x /bin/zapret
    fi
    manage_service restart
    sleep 2
    exec sudo "$0" "$@"
}

update_script() {
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        cd /opt/zapret/zapret.cfgs && git pull
    fi
    if [[ -d /opt/zapret.installer/ ]]; then
        cd /opt/zapret.installer/ && git pull
    fi

    exec sudo "$0" "$@"
}

add_to_zapret() {
    read -p "Введите IP-адреса или домены для добавления в лист (разделяйте пробелами, запятыми или |)(Enter для отмены): " input
    
    if [[ -z "$input" ]]; then
        main_menu
    fi

    IFS=',| ' read -ra ADDRESSES <<< "$input"

    for address in "${ADDRESSES[@]}"; do
        address=$(echo "$address" | xargs)
        if [[ -n "$address" && ! $(grep -Fxq "$address" "/opt/zapret/ipset/zapret-hosts-user.txt") ]]; then
            echo "$address" >> "/opt/zapret/ipset/zapret-hosts-user.txt"
            echo "Добавлено: $address"
        else
            echo "Уже существует: $address"
        fi
    done
    
    manage_service restart

    echo "Готово"
    sleep 2
    main_menu
}

delete_from_zapret() {
    read -p "Введите IP-адреса или домены для удаления из листа (разделяйте пробелами, запятыми или |)(Enter для отмены): " input

    if [[ -z "$input" ]]; then
        main_menu
    fi

    IFS=',| ' read -ra ADDRESSES <<< "$input"

    for address in "${ADDRESSES[@]}"; do
        address=$(echo "$address" | xargs)
        if [[ -n "$address" ]]; then
            if grep -Fxq "$address" "/opt/zapret/ipset/zapret-hosts-user.txt"; then
                sed -i "\|^$address\$|d" "/opt/zapret/ipset/zapret-hosts-user.txt"
                echo "Удалено: $address"
            else
                echo "Не найдено: $address"
            fi
        fi
    done

    manage_service restart

    echo "Готово"
    sleep 2
    main_menu
}

search_in_zapret() {
    read -p "Введите слово для поиска в хостлисте (Enter для отмены): " keyword

    if [[ -z "$keyword" ]]; then
        main_menu
    fi

    matches=$(grep "$keyword" "/opt/zapret/ipset/zapret-hosts-user.txt")

    if [[ -n "$matches" ]]; then
        echo "Найденные записи:"
        echo "$matches"
    else
        echo "Совпадений не найдено."
    fi
}

configure_zapret_conf() {
    if [[ ! -d /opt/zapret/zapret.cfgs ]]; then
        echo "Клонирую конфигурации..."
        if ! git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs ; then
            echo "Ошибка: нестабильноe/слабое подключение к интернету."
            exit 1
        fi
            echo "Клонирование успешно завершено."
            sleep 2
    fi
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        echo "Проверяю наличие на обновление конфигураций..."
        cd /opt/zapret/zapret.cfgs && git pull
        sleep 2
    fi

    clear


    echo "Выберите стратегию (можно поменять в любой момент, запустив Меню управления запретом еще раз):"
    PS3="Введите номер стратегии (по умолчанию 6): "

    select CONF in /opt/zapret/zapret.cfgs/configurations/* "Отмена"; do

    
        if [[ "$CONF" == "Отмена" ]]; then
            main_menu
        elif [[ -n "$CONF" ]]; then
            rm -f /opt/zapret/config
            cp "$CONF" /opt/zapret/config
            echo "Стратегия '$CONF' установлена."
            sleep 2
            break
        else
            echo "Неверный выбор, попробуйте снова."
        fi
    done

   
    get_fwtype

    sed -i "s/^FWTYPE=.*/FWTYPE=$FWTYPE/" /opt/zapret/config

    manage_service restart
    
    main_menu
}

configure_zapret_list() {
    if [[ ! -d /opt/zapret/zapret.cfgs ]]; then
        echo "Клонирую конфигурации..."
        if ! git clone https://github.com/Snowy-Fluffy/zapret.cfgs /opt/zapret/zapret.cfgs ; then
            echo "Ошибка: нестабильноe/слабое подключение к интернету."
            exit 1
        fi
            echo "Клонирование успешно завершено."
            sleep 2
    fi
    if [[ -d /opt/zapret/zapret.cfgs ]]; then
        echo "Проверяю наличие на обновление конфигураций..."
        cd /opt/zapret/zapret.cfgs && git pull
        sleep 2
    fi

    clear

    echo "Выберите хостлист (можно поменять в любой момент, запустив Меню управления запретом еще раз):"
    PS3="Введите номер листа (по умолчанию 2): "
    select LIST in /opt/zapret/zapret.cfgs/lists/list* "Отмена"; do
        if [[ "$LIST" == "Отмена" ]]; then
            main_menu
        elif [[ -n "$LIST" ]]; then
            rm -f /opt/zapret/ipset/zapret-hosts-user.txt
            cp "$LIST" /opt/zapret/ipset/zapret-hosts-user.txt
            echo "Хостлист '$LIST' установлен."
            sleep 2
            break
        else
            echo "Неверный выбор, попробуйте снова."
        fi
    done

    manage_service restart
    
    main_menu
}

uninstall_zapret() {
    read -p "Вы действительно хотите удалить запрет? (y/N): " answer
    case "$answer" in
        [Yy]* ) 
            if [[ -f /opt/zapret/uninstall_easy.sh ]]; then
                cd /opt/zapret
                yes "" | ./uninstall_easy.sh
            fi
            rm -rf /opt/zapret
            rm -rf /opt/zapret.installer/
            rm -r /bin/zapret
            ;;
        * ) 
            main_menu
            ;;
    esac
}


detect_init
main_menu
